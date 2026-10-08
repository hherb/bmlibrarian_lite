"""The Elsevier key and institutional token in the desktop's settings (#480, stage C2)."""

from __future__ import annotations

import argparse
import json
import stat
from pathlib import Path

import pytest

from bmlibrarian_lite import cli
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.constants import (
    ELSEVIER_API_KEY_EXPLANATION,
    ELSEVIER_API_KEY_FROM_ENVIRONMENT,
    ELSEVIER_INSTTOKEN_EXPLANATION,
    ELSEVIER_INSTTOKEN_FROM_ENVIRONMENT,
    ENV_ELSEVIER_API_KEY,
    ENV_ELSEVIER_INSTTOKEN,
    REDACTED_SECRET_PLACEHOLDER,
)

KEY = "test-elsevier-key-0123456789"
TOKEN = "test-elsevier-token-ABCDEF"

#: The two settings, by field name, with a value for each.
SECRETS = {"elsevier_api_key": KEY, "elsevier_insttoken": TOKEN}


def test_the_explanations_are_the_contracts() -> None:
    """Verbatim on every platform (global constraints)."""
    assert ELSEVIER_API_KEY_EXPLANATION == (
        "Optional. A free Elsevier API key (dev.elsevier.com) lets the app download "
        "the PDFs of Elsevier articles you are entitled to: open-access articles "
        "anywhere, subscribed ones from your institution's network."
    )
    assert ELSEVIER_INSTTOKEN_EXPLANATION == (
        "Optional. An institutional token from Elsevier lets the key use your "
        "institution's subscriptions away from its network."
    )


@pytest.mark.parametrize("name", SECRETS)
def test_each_defaults_to_none(name: str) -> None:
    """Nothing until the user sets it."""
    assert getattr(LiteConfig().discovery, name) is None


def test_both_round_trip_through_the_owner_only_file(tmp_path: Path) -> None:
    """Saved with the other secrets, readable by the owner alone."""
    config = LiteConfig()
    config.discovery.elsevier_api_key = KEY
    config.discovery.elsevier_insttoken = TOKEN
    path = tmp_path / "config.json"
    config.save(path)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    loaded = LiteConfig.load(path)
    assert loaded.discovery.elsevier_api_key == KEY
    assert loaded.discovery.elsevier_insttoken == TOKEN


def test_an_export_carries_neither() -> None:
    """The redacted form names that each is set, not what it is."""
    config = LiteConfig()
    config.discovery.elsevier_api_key = KEY
    config.discovery.elsevier_insttoken = TOKEN
    redacted = config.to_redacted_dict()
    for name in SECRETS:
        assert redacted["discovery"][name] == REDACTED_SECRET_PLACEHOLDER
    assert KEY not in json.dumps(redacted) and TOKEN not in json.dumps(redacted)
    # The control: unset stays unset
    assert LiteConfig().to_redacted_dict()["discovery"]["elsevier_insttoken"] is None


@pytest.mark.parametrize("name", SECRETS)
def test_a_redacted_export_loaded_back_is_no_secret(tmp_path: Path, name: str) -> None:
    """The placeholder is never sent to Elsevier as a key or a token."""
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"discovery": {name: REDACTED_SECRET_PLACEHOLDER}}))
    assert getattr(LiteConfig.load(path).discovery, name) is None


@pytest.mark.parametrize("name", SECRETS)
@pytest.mark.parametrize("value", [12345, ["k"], {"k": 1}, True])
def test_a_value_that_is_not_text_is_none(tmp_path: Path, name: str, value: object) -> None:
    """A number or a list typed into the file is ignored, not a start-up crash."""
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"discovery": {name: value}}))
    assert getattr(LiteConfig.load(path).discovery, name) is None


def test_the_other_discovery_fields_survive_beside_them(tmp_path: Path) -> None:
    """Control: the section's other fields are still read."""
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"discovery": {
        "unpaywall_email": "a@b.org", "core_api_key": "core", "elsevier_api_key": KEY,
    }}))
    loaded = LiteConfig.load(path).discovery
    assert loaded.unpaywall_email == "a@b.org"
    assert loaded.core_api_key == "core"
    assert loaded.elsevier_api_key == KEY
    assert loaded.elsevier_insttoken is None


def test_neither_is_in_the_repr() -> None:
    """Printing or logging the configuration shows neither."""
    config = LiteConfig()
    config.discovery.elsevier_api_key = KEY
    config.discovery.elsevier_insttoken = TOKEN
    assert KEY not in repr(config) and TOKEN not in repr(config)
    config.discovery.unpaywall_email = "a@b.org"
    assert "a@b.org" in repr(config)


@pytest.mark.parametrize(
    ("value", "expected"),
    [("set", REDACTED_SECRET_PLACEHOLDER), (None, "(not set)")],
)
def test_the_cli_config_view_never_prints_either(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    value: str | None,
    expected: str,
) -> None:
    """The human view says whether each is set, never what it is."""
    config = LiteConfig()
    config.discovery.elsevier_api_key = KEY if value else None
    config.discovery.elsevier_insttoken = TOKEN if value else None
    monkeypatch.setattr(LiteConfig, "load", classmethod(lambda cls, path=None: config))
    assert cli.cmd_config(argparse.Namespace(json=False)) == 0
    lines = capsys.readouterr().out.splitlines()
    assert f"  Elsevier API key: {expected}" in lines
    assert f"  Elsevier institutional token: {expected}" in lines
    assert not any(KEY in line or TOKEN in line for line in lines)


def test_the_cli_json_view_never_prints_either(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The JSON view is the redacted dictionary."""
    config = LiteConfig()
    config.discovery.elsevier_api_key = KEY
    config.discovery.elsevier_insttoken = TOKEN
    monkeypatch.setattr(LiteConfig, "load", classmethod(lambda cls, path=None: config))
    assert cli.cmd_config(argparse.Namespace(json=True)) == 0
    out = capsys.readouterr().out
    assert KEY not in out and TOKEN not in out
    assert json.loads(out)["discovery"]["elsevier_api_key"] == REDACTED_SECRET_PLACEHOLDER


@pytest.fixture
def qapp():
    """A QApplication for the dialog tests."""
    pytest.importorskip("PySide6")
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


def _inputs(dialog):
    return {
        "elsevier_api_key": dialog.elsevier_api_key_input,
        "elsevier_insttoken": dialog.elsevier_insttoken_input,
    }


def test_the_fields_are_masked_and_explained(qapp) -> None:
    """Password echo; the tooltips are the explanations."""
    from PySide6.QtWidgets import QLineEdit

    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    dialog = SettingsDialog(LiteConfig())
    key, token = dialog.elsevier_api_key_input, dialog.elsevier_insttoken_input
    assert key.echoMode() == QLineEdit.EchoMode.Password
    assert token.echoMode() == QLineEdit.EchoMode.Password
    assert key.toolTip() == ELSEVIER_API_KEY_EXPLANATION
    assert token.toolTip() == ELSEVIER_INSTTOKEN_EXPLANATION
    assert key.placeholderText() == "Optional" == token.placeholderText()


def test_the_fields_sit_in_the_full_text_tab_under_cores(qapp) -> None:
    """Beside CORE's key, in the Full Text tab."""
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    dialog = SettingsDialog(LiteConfig())
    tab = dialog.core_api_key_input.parentWidget()
    assert dialog.elsevier_api_key_input.parentWidget() is tab
    assert dialog.elsevier_insttoken_input.parentWidget() is tab
    layout = tab.layout()
    rows = [layout.getWidgetPosition(w)[0] for w in (
        dialog.core_api_key_input,
        dialog.elsevier_api_key_input,
        dialog.elsevier_insttoken_input,
    )]
    assert rows == sorted(rows) and len(set(rows)) == 3


def test_the_dialog_saves_and_clears_both(qapp, monkeypatch) -> None:
    """The fields write the settings stripped; empty fields clear them."""
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    config = LiteConfig()
    monkeypatch.setattr(LiteConfig, "save", lambda self, *a, **k: None)
    dialog = SettingsDialog(config)
    dialog.elsevier_api_key_input.setText(f"  {KEY}  ")
    dialog.elsevier_insttoken_input.setText(f"\t{TOKEN} ")
    dialog._save_config()
    assert config.discovery.elsevier_api_key == KEY
    assert config.discovery.elsevier_insttoken == TOKEN
    dialog.elsevier_api_key_input.setText("")
    dialog.elsevier_insttoken_input.setText("  ")
    dialog._save_config()
    assert config.discovery.elsevier_api_key is None
    assert config.discovery.elsevier_insttoken is None


def test_the_dialog_shows_saved_values(qapp) -> None:
    """Opening the dialog loads both into their fields."""
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    config = LiteConfig()
    config.discovery.elsevier_api_key = KEY
    config.discovery.elsevier_insttoken = TOKEN
    dialog = SettingsDialog(config)
    assert dialog.elsevier_api_key_input.text() == KEY
    assert dialog.elsevier_insttoken_input.text() == TOKEN


@pytest.mark.parametrize(
    ("name", "env", "placeholder"),
    [
        ("elsevier_api_key", ENV_ELSEVIER_API_KEY, ELSEVIER_API_KEY_FROM_ENVIRONMENT),
        ("elsevier_insttoken", ENV_ELSEVIER_INSTTOKEN, ELSEVIER_INSTTOKEN_FROM_ENVIRONMENT),
    ],
)
def test_the_dialog_says_when_a_value_comes_from_the_environment(
    qapp, monkeypatch, name: str, env: str, placeholder: str
) -> None:
    """A refusal is told as "the key in the settings": the field says where it is."""
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    monkeypatch.setenv(env, SECRETS[name])
    field = _inputs(SettingsDialog(LiteConfig()))[name]
    assert field.text() == ""
    assert field.placeholderText() == placeholder
    monkeypatch.delenv(env)
    assert _inputs(SettingsDialog(LiteConfig()))[name].placeholderText() == "Optional"


def test_a_save_that_fails_is_told_and_keeps_the_dialog_open(qapp, monkeypatch) -> None:
    """The reader is told the settings will not survive a restart; neither secret shown."""
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
    dialog.elsevier_api_key_input.setText(KEY)
    dialog.elsevier_insttoken_input.setText(TOKEN)
    dialog._save_config()
    assert accepted == []
    assert len(shown) == 1 and "PermissionError" in shown[0]
    assert KEY not in shown[0] and TOKEN not in shown[0]
